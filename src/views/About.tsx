import React from 'react';
import { Typography, Box } from '@mui/material';

function About() {
	return (
		<Box
			sx={{ padding: { xs: '20px', md: '100px' }, backgroundColor: '#0D2F4B' }}
		>
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
				About
			</Typography>
			<Box
				sx={{
					height: '2.5px',
					width: '80px',
					backgroundColor: '#fec86a',
					marginRight: '32px',
					fontSize: { xs: '32px', md: '56px' },
				}}
			/>
			<Typography
				sx={{
					color: '#fbfbfb',
					textAlign: 'justify',
					maxWidth: '100%',
					paddingRight: '20%',
					fontSize: { xs: '18px', md: '25px' },
					marginTop: { xs: '10px', md: '15px' },
				}}
			>
				Experienced Software Engineer Decision Maker and Leader Over 6 years of
				experience in software engineering and application development,
				specializing in Android mobile platforms. Proven ability as a consultant
				and coach, I am adept at guiding highly talented groups. I am committed
				to working collaboratively with teams and clients, focusing on
				optimizing and implementing the most effective solutions. As the manager
				of a 5-person team, I oversee software development, API design, and
				development processes. In addition, I play a key role in determining
				strategic business decisions for the company’s projects, ensuring
				alignment with business objectives and technological developments.
			</Typography>
		</Box>
	);
}

export default About;
