import React from 'react';
import Box from '@mui/material/Box';
import Typography from '@mui/material/Typography';
import Grid from '@mui/material/Grid';
import Paper from '@mui/material/Paper';
import PhoneIcon from '@mui/icons-material/Phone';
import EmailIcon from '@mui/icons-material/Email';
import LocationOnIcon from '@mui/icons-material/LocationOn';

const ContactCard: React.FC<{ icon: JSX.Element; text: string }> = ({
	icon,
	text,
}) => {
	return (
		<div style={{ display: 'flex', flexDirection: 'column' }}>
			<Paper
				sx={{
					backgroundColor: '#fec86a',
					padding: '10px',
					borderRadius: '8px',
					display: 'flex',
					gap: '10px',
				}}
			>
				{icon}
				<Typography variant="body1" sx={{ color: '#34353b' }}>
					{text}
				</Typography>
			</Paper>
		</div>
	);
};

const Contact: React.FC = () => {
	return (
		<Box sx={{ padding: '50px 100px', backgroundColor: '#0D2F4B' }}>
			<Typography
				variant="h1"
				sx={{
					fontSize: '56px',
					fontWeight: 700,
					color: '#fbfbfb',
					fontFamily: 'Libre Baskerville, serif',
					marginBottom: '30px',
				}}
			>
				Contact Me
			</Typography>
			<Box
				sx={{
					height: '2.5px',
					width: '80px',
					backgroundColor: '#fec86a',
					marginRight: '32px',
				}}
			/>
			<Grid container spacing={2} justifyContent="center" marginTop={2}>
				<Grid item>
					<ContactCard icon={<PhoneIcon />} text="+34 671-904-482" />
				</Grid>
				<Grid item>
					<ContactCard icon={<EmailIcon />} text="edison.saez@hotmail.cl" />
				</Grid>
				<Grid item>
					<ContactCard icon={<LocationOnIcon />} text="Barcelona, Spain" />
				</Grid>
			</Grid>
		</Box>
	);
};

export default Contact;
